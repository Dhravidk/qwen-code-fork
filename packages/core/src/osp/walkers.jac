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
