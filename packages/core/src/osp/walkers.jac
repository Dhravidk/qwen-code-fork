# @license
# Copyright 2025 Google LLC
# SPDX-License-Identifier: Apache-2.0

# Jac walkers that implement the Phase 0 Execution Trace Graph (ETG) and Code Graph
# surface defined in docs/INTERFACES.md. The walkers are intentionally verbose and
# documented so downstream tooling can mirror the intended behaviour even without
# a full runtime.

walker IndexProject {
    has project_root: str;
    has mode: str = "full"; # "full" or "incremental"

    root {
        assert project_root, "project_root is required";
        # Ensure a single project node exists for the root path.
        with entry_project = spawn here ++:project {
            .id = digest(project_root);
            .root_path = project_root;
        }

        # Traverse the filesystem to build directories, files, and symbol edges.
        files_indexed = 0;
        symbols_indexed = 0;
        concepts_indexed = 0;

        for dir_path in fs.dir_walk(project_root) {
            with d = spawn here ++:directory {
                .path = dir_path;
            }
            connect(entry_project, d, project_contains_dir);

            for subdir in fs.list_dirs(dir_path) {
                with sd = spawn here ++:directory {
                    .path = subdir;
                }
                connect(d, sd, dir_contains_dir);
            }

            for f_path in fs.list_files(dir_path) {
                meta = fs.meta(f_path);
                with f = spawn here ++:file {
                    .path = f_path;
                    .language = detect_lang(f_path);
                    .size_bytes = meta.size;
                    .hash = digest_file(f_path);
                    .last_modified = meta.mtime;
                }
                files_indexed += 1;
                connect(d, f, dir_contains_file);

                for sym in parse_symbols(f_path) {
                    with s = spawn here ++:symbol {
                        .name = sym.name;
                        .kind = sym.kind;
                        .signature = sym.signature;
                        .span_start_line = sym.span.start;
                        .span_end_line = sym.span.end;
                        .docstring = sym.docstring;
                    }
                    symbols_indexed += 1;
                    connect(f, s, file_contains_symbol);
                    for call in sym.calls {
                        connect(s, call, symbol_calls_symbol);
                    }
                    for tested in sym.tests {
                        connect(s, tested, symbol_tests_symbol);
                    }
                    for concept in sym.concepts {
                        connect(s, concept, symbol_implements_concept);
                        concepts_indexed += 1;
                    }
                }
            }
        }

        report {"files_indexed": files_indexed,
                "symbols_indexed": symbols_indexed,
                "concepts_indexed": concepts_indexed,
                "duration_ms": timer.stop()};
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
