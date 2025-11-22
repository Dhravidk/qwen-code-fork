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
