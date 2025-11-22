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

    # Expected payloads align with docs/INTERFACES.md:
    #   task_start  -> { user_prompt: str, tags?: list, concepts?: list, task_id?: str }
    #   step        -> { order: int, role?: str, llm_summary?: str, files_touched?: list, step_id?: str }
    #   tool_start  -> { tool_name: str, params_json?: dict, files_touched?: list, invocation_id?: str, step_id?: str }
    #   tool_end    -> { tool_name: str, success: bool, duration_ms?: int, stdout?: str, stderr?: str,
    #                    files_touched?: list, invocation_id?: str, step_id?: str }
    #   checkpoint  -> { checkpoint_file: str, created_at?: str, step_id?: str }
    #   error       -> { error_type: str, message: str, raw_log_excerpt?: str, error_id?: str, step_id?: str }
    #   task_end    -> { status: str }
    # The walker returns correlation hints: { task_id, step_id | null, tool_id | null }.

    root {
        assert project_root, "project_root is required";
        assert kind, "kind is required";

        project_id = digest(project_root);

        if here-->project(id=project_id) {
            with project_node = here-->project(id=project_id) { }
        } else {
            with project_node = spawn here ++:project {
                .id = project_id;
                .root_path = project_root;
            }
        }

        if payload.get("task_id", null) {
            task_id = payload.task_id;
        }

        if kind == "task_start" {
            if not task_id {
                task_id = payload.get("task_id", gen_uuid());
            }

            if project_node-->task(id=task_id) {
                with task_node = project_node-->task(id=task_id) { }
            } else {
                with task_node = spawn project_node ++:task {
                    .id = task_id;
                    .created_at = payload.get("created_at", now());
                    .user_prompt = payload.user_prompt;
                    .project_id = project_node.id;
                    .status = "running";
                    .tags = payload.get("tags", []);
                    .files_touched = [];
                    .embedding = [];
                }
            }

            for concept_label in payload.get("concepts", []) {
                if project_node-->concept(label=concept_label) {
                    with concept_node = project_node-->concept(label=concept_label) { }
                } else {
                    with concept_node = spawn project_node ++:concept {
                        .label = concept_label;
                        .description = "";
                        .source = "manual";
                    }
                }
                connect(task_node, concept_node, task_related_to_concept);
            }

            report {"task_id": task_id, "step_id": null, "tool_id": null};
        }

        if kind == "step" {
            assert task_id, "step requires a task_id";

            if project_node-->task(id=task_id) {
                with task_node = project_node-->task(id=task_id) { }
            } else {
                with task_node = spawn project_node ++:task {
                    .id = task_id;
                    .created_at = payload.get("created_at", now());
                    .user_prompt = "";
                    .project_id = project_node.id;
                    .status = "running";
                    .tags = [];
                    .files_touched = [];
                    .embedding = [];
                }
            }

            step_id = payload.get("step_id", gen_uuid());
            with step_node = spawn project_node ++:step {
                .id = step_id;
                .order = payload.order;
                .role = payload.get("role", "");
                .llm_summary = payload.get("llm_summary", "");
                .files_touched = payload.get("files_touched", []);
                .embedding = [];
            }
            connect(task_node, step_node, task_has_step);
            report {"task_id": task_id, "step_id": step_node.id, "tool_id": null};
        }

        if kind == "tool_start" {
            assert task_id, "tool_start requires a task_id";

            if project_node-->task(id=task_id) {
                with task_node = project_node-->task(id=task_id) { }
            }

            with current_step = null;
            if payload.get("step_id", null) {
                with current_step = project_node-->step(id=payload.step_id) { }
            } else {
                for s in task_node-->task_has_step { current_step = s; }
            }

            assert current_step, "step must exist before tool_start";

            tool_id = payload.get("invocation_id", gen_uuid());
            with tool_node = spawn project_node ++:tool_invocation {
                .id = tool_id;
                .tool_name = payload.tool_name;
                .params_json = payload.get("params_json", {});
                .started_at = payload.get("started_at", now());
                .duration_ms = 0;
                .success = true;
                .stdout = "";
                .stderr = "";
                .files_touched = payload.get("files_touched", []);
            }
            connect(current_step, tool_node, step_invokes_tool);

            for f_path in payload.get("files_touched", []) {
                if project_node-->file(path=f_path) {
                    with file_node = project_node-->file(path=f_path) { }
                } else {
                    with file_node = spawn project_node ++:file {
                        .path = f_path;
                        .language = "";
                        .size_bytes = 0;
                        .hash = "";
                        .last_modified = "";
                    }
                }
                connect(tool_node, file_node, tool_touches_file);
            }

            for touched in payload.get("files_touched", []) {
                if touched not in current_step.files_touched { current_step.files_touched.append(touched); }
                if task_node and touched not in task_node.files_touched { task_node.files_touched.append(touched); }
            }

            report {"task_id": task_id, "step_id": current_step.id, "tool_id": tool_node.id};
        }

        if kind == "tool_end" {
            assert task_id, "tool_end requires a task_id";

            if project_node-->task(id=task_id) {
                with task_node = project_node-->task(id=task_id) { }
            }

            with current_step = null;
            if payload.get("step_id", null) {
                with current_step = project_node-->step(id=payload.step_id) { }
            } else {
                for s in task_node-->task_has_step { current_step = s; }
            }

            assert current_step, "step must exist before tool_end";

            with tool_node = null;
            if payload.get("invocation_id", null) and project_node-->tool_invocation(id=payload.invocation_id) {
                with tool_node = project_node-->tool_invocation(id=payload.invocation_id) { }
            } else {
                for candidate in current_step-->step_invokes_tool { if candidate.tool_name == payload.tool_name { tool_node = candidate; } }
            }

            if not tool_node {
                with tool_node = spawn project_node ++:tool_invocation {
                    .id = payload.get("invocation_id", gen_uuid());
                    .tool_name = payload.tool_name;
                    .params_json = payload.get("params_json", {});
                    .started_at = payload.get("started_at", now());
                    .files_touched = payload.get("files_touched", []);
                }
                connect(current_step, tool_node, step_invokes_tool);
            }

            tool_node.success = payload.success;
            tool_node.duration_ms = payload.get("duration_ms", tool_node.duration_ms or 0);
            tool_node.stdout = payload.get("stdout", tool_node.stdout or "");
            tool_node.stderr = payload.get("stderr", tool_node.stderr or "");
            if payload.get("files_touched", []) {
                tool_node.files_touched = payload.files_touched;
            }

            for f_path in tool_node.files_touched {
                if project_node-->file(path=f_path) {
                    with file_node = project_node-->file(path=f_path) { }
                } else {
                    with file_node = spawn project_node ++:file {
                        .path = f_path;
                        .language = "";
                        .size_bytes = 0;
                        .hash = "";
                        .last_modified = "";
                    }
                }
                connect(tool_node, file_node, tool_touches_file);
                if current_step and f_path not in current_step.files_touched { current_step.files_touched.append(f_path); }
                if task_node and f_path not in task_node.files_touched { task_node.files_touched.append(f_path); }
            }

            report {"task_id": task_id, "step_id": current_step.id, "tool_id": tool_node.id};
        }

        if kind == "checkpoint" {
            assert task_id, "checkpoint requires a task_id";

            with current_step = null;
            if payload.get("step_id", null) {
                with current_step = project_node-->step(id=payload.step_id) { }
            } else {
                for s in project_node-->step { current_step = s; }
            }

            assert current_step, "step must exist before checkpoint";

            checkpoint_id = payload.get("checkpoint_id", gen_uuid());
            with checkpoint_node = spawn current_step ++:checkpoint_node {
                .id = checkpoint_id;
                .checkpoint_file = payload.checkpoint_file;
                .created_at = payload.get("created_at", now());
            }
            connect(current_step, checkpoint_node, step_has_checkpoint);
            report {"task_id": task_id, "step_id": current_step.id, "tool_id": null};
        }

        if kind == "error" {
            assert task_id, "error requires a task_id";

            with current_step = null;
            if payload.get("step_id", null) {
                with current_step = project_node-->step(id=payload.step_id) { }
            } else {
                for s in project_node-->step { current_step = s; }
            }

            assert current_step, "step must exist before error";

            error_id = payload.get("error_id", gen_uuid());
            with error_node = spawn current_step ++:error {
                .id = error_id;
                .error_type = payload.error_type;
                .message = payload.message;
                .raw_log_excerpt = payload.get("raw_log_excerpt", "");
            }
            connect(current_step, error_node, step_has_error);
            report {"task_id": task_id, "step_id": current_step.id, "tool_id": null};
        }

        if kind == "task_end" {
            assert task_id, "task_end requires a task_id";

            if project_node-->task(id=task_id) {
                with task_node = project_node-->task(id=task_id) { }
            } else {
                with task_node = spawn project_node ++:task {
                    .id = task_id;
                    .created_at = payload.get("created_at", now());
                    .user_prompt = "";
                    .project_id = project_node.id;
                    .status = "running";
                    .tags = [];
                    .files_touched = [];
                    .embedding = [];
                }
            }

            task_node.status = payload.status;
            report {"task_id": task_id, "step_id": null, "tool_id": null};
        }
    }
}

walker SimilarAttempts {
    has project_root: str;
    has query: str;
    has file_paths: list = [];
    has limit: int = 5;

    """
    Purpose: Retrieve the most relevant historical Tasks/Steps from the ETG so
    the MCP server can surface prior attempts to the LLM before making new
    changes.

    Inputs (per docs/INTERFACES.md):
        - project_root: Absolute root of the project.
        - query: Natural language query from the LLM/user.
        - file_paths: Optional file filter; when provided we only return steps
          that touched at least one of the files.
        - limit: Max number of entries to return (defaults to 5 for token safety).

    Outputs:
        - results: JSON-friendly list of {task_id, step_id, files, score,
          summary, errors} sorted by descending relevance.
        - summary_markdown: Compact Markdown narrative designed to be injected
          directly into an LLM prompt.

    Relevance scoring uses a lightweight keyword-overlap placeholder. It should
    be swapped for embedding similarity once available (kept simple here to
    avoid extra dependencies in Phase 0).
    """

    root {
        assert project_root, "project_root is required";
        assert query, "query is required";

        with project_node = spawn here ++:project {
            .id = digest(project_root);
            .root_path = project_root;
        }

        # Basic tokenization for keyword overlap scoring.
        query_tokens = [];
        for tok in lower(query).split() { if tok != "" { query_tokens.append(tok); } }

        results = [];

        for step_node in project_node-->step {
            with task_node = step_node<-task_has_step { }

            # Collect the files touched by the step and its tools (deduplicated).
            touched = [];
            for p in step_node.files_touched or [] { touched.append(p); }
            for tool in step_node-->step_invokes_tool {
                for p in tool.files_touched or [] { touched.append(p); }
                for f in tool-->tool_touches_file { touched.append(f.path); }
            }
            dedup_files = [];
            for fp in touched { if fp not in dedup_files { dedup_files.append(fp); } }

            overlap_count = 0;
            for fp in file_paths { if fp in dedup_files { overlap_count += 1; } }

            # If a file filter is provided, skip unrelated steps to bias toward
            # the files the LLM is currently editing.
            if file_paths and overlap_count == 0 { continue; }

            # Build a compact text blob for scoring.
            tags_text = "";
            for tag in task_node.tags or [] { tags_text += tag + " "; }
            errors_text = "";
            for err in step_node-->step_has_error { errors_text += err.message + " " + err.raw_log_excerpt + " "; }
            files_text = "";
            for fp in dedup_files { files_text += fp + " "; }

            context_blob = task_node.user_prompt + " " + tags_text + " " + step_node.llm_summary + " " + errors_text + files_text;
            blob_lower = lower(context_blob);

            score = overlap_count * 2; # simple boost for file overlap
            for token in query_tokens { if blob_lower.find(token) >= 0 { score += 1; } }

            summary_text = step_node.llm_summary;
            if summary_text == "" { summary_text = context_blob; }
            # Truncate to keep prompt injection cheap; tune threshold if needed.
            if len(summary_text) > 320 { summary_text = summary_text[:320] + "..."; }

            error_summaries = [];
            for err in step_node-->step_has_error {
                err_line = err.error_type + ": " + err.message;
                if len(err_line) > 200 { err_line = err_line[:200] + "..."; }
                error_summaries.append(err_line);
            }

            results.append({"task_id": task_node.id,
                             "step_id": step_node.id,
                             "files": dedup_files,
                             "score": score,
                             "summary": summary_text,
                             "errors": error_summaries});
        }

        results = sort_desc(results, "score")[:limit];

        # Markdown summary suitable for direct prompt injection.
        summary_lines = [];
        for r in results {
            files_text = "";
            shown = 0;
            for fp in r.files { if shown < 3 { files_text += "`" + fp + "` "; shown += 1; } }
            error_text = "";
            if len(r.errors) > 0 { error_text = " Errors: " + " | ".join(r.errors); }
            summary_lines.append("- Task " + r.task_id + ", Step " + r.step_id + ": " + r.summary + " Files: " + files_text + error_text);
        }
        summary_markdown = "\n".join(summary_lines);

        report {"results": results, "summary_markdown": summary_markdown};
    }
}

walker ContextForFiles {
    has project_root: str;
    has file_paths: list;
    has radius: int = 1;

    """
    Purpose: Produce a compact "context pack" describing the local code graph
    and recent ETG activity for a set of files. MCP can present the Markdown to
    the LLM for quick grounding and use the structured payload for tool usage.

    Inputs (per docs/INTERFACES.md):
        - project_root: Absolute root of the project.
        - file_paths: Files to inspect (absolute or project-relative).
        - radius: Hop distance for symbol/concept traversal (defaults to 1 to
          avoid large payloads).

    Outputs:
        - context_pack: List of file-scoped summaries containing symbols,
          concepts, tasks/steps, and errors touching the files.
        - returnDisplay: Markdown digest that is safe to drop directly into an
          LLM prompt.
    """

    root {
        assert project_root, "project_root is required";
        assert file_paths and len(file_paths) > 0, "file_paths are required";

        with project_node = spawn here ++:project {
            .id = digest(project_root);
            .root_path = project_root;
        }

        file_contexts = [];
        summary_lines = [];

        for target_path in file_paths {
            # Locate the file node; skip if missing to avoid noisy failures.
            target_file = null;
            for f in project_node-->file(path=target_path) { target_file = f; }
            if not target_file { continue; }

            symbols = [];
            concepts = [];
            step_entries = [];

            # Symbols directly contained in the file plus nearby symbols/concepts.
            for sym in target_file-->file_contains_symbol {
                symbols.append(sym.name);
                for hop in bfs(sym, radius) {
                    if hop isa symbol and hop.name not in symbols { symbols.append(hop.name); }
                    if hop isa concept and hop.label not in concepts { concepts.append(hop.label); }
                }
                for c in sym-->symbol_implements_concept { if c.label not in concepts { concepts.append(c.label); } }
            }
            for c in target_file-->file_mentions_concept { if c.label not in concepts { concepts.append(c.label); } }

            # ETG steps/tasks that touched this file via tool invocations.
            for tool in target_file<--tool_touches_file {
                for step_node in tool<-step_invokes_tool {
                    with task_node = step_node<-task_has_step { }
                    # Collect a short summary and most recent error (if any).
                    err_summary = "";
                    for err in step_node-->step_has_error { err_summary = err.error_type + ": " + err.message; break; }
                    step_summary = step_node.llm_summary;
                    if step_summary == "" { step_summary = task_node.user_prompt; }
                    if len(step_summary) > 220 { step_summary = step_summary[:220] + "..."; }

                    step_entries.append({"task_id": task_node.id,
                                          "step_id": step_node.id,
                                          "summary": step_summary,
                                          "error": err_summary});
                }
            }

            # Trim to a handful of steps per file to keep payload lean.
            if len(step_entries) > 3 { step_entries = step_entries[:3]; }

            file_contexts.append({"file": target_path,
                                  "symbols": symbols,
                                  "concepts": concepts,
                                  "steps": step_entries});

            # Markdown line for the LLM.
            line = "- File: `" + target_path + "`\n";
            if len(symbols) > 0 { line += "  - Symbols: [" + ", ".join(symbols) + "]\n"; }
            if len(concepts) > 0 { line += "  - Related concepts: [" + ", ".join(concepts) + "]\n"; }
            if len(step_entries) > 0 {
                line += "  - Past tasks:\n";
                for entry in step_entries {
                    err_note = "";
                    if entry.error != "" { err_note = " (error: " + entry.error + ")"; }
                    line += "    - Task " + entry.task_id + ", Step " + entry.step_id + ": " + entry.summary + err_note + "\n";
                }
            }
            summary_lines.append(line);
        }

        summary_markdown = "\n".join(summary_lines);

        report {"context_pack": file_contexts,
                "returnDisplay": summary_markdown};
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
