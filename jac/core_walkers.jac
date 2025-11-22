// Minimal helper walkers for the ETG + Code Graph schema.
// These walkers are intentionally small and documented so downstream
// agents can extend them as needed.

include "nodes.jac";

walker get_or_create_project {
    has root_path: str;

    root {
        assert root_path, "root_path is required";
        with proj = spawn here ++:project {
            .id = digest(root_path);
            .project_id = .id;
            .root_path = root_path;
        }
        report proj;
    }
}

walker fetch_project_summary {
    has root_path: str;

    root {
        assert root_path, "root_path is required";
        with proj = here-->project(root_path=root_path) {
            dirs = [];  // collect immediate child directories
            for d in proj->project_contains_dir {
                dirs.append(d.path);
            }
            report {
                "project_id": proj.id,
                "root_path": proj.root_path,
                "directories": dirs,
            };
        }
    }
}

walker demo_seed_graph {
    /*
    Creates a tiny in-memory example graph for smoke testing:
    - Project rooted at /demo
    - Directory src containing a file main.py
    - Symbol demo_func inside main.py
    - Task with one step and a tool invocation touching main.py
    */
    root {
        with proj = spawn here ++:project {
            .id = digest("/demo");
            .project_id = .id;
            .root_path = "/demo";
        }

        with src_dir = spawn proj ++:directory {
            .path = "/demo/src";
        }
        connect(proj, src_dir, project_contains_dir);

        with f = spawn src_dir ++:file {
            .path = "/demo/src/main.py";
            .language = "python";
            .size_bytes = 42;
            .hash = "deadbeef";
            .last_modified = now();
        }
        connect(src_dir, f, dir_contains_file);

        with sym = spawn f ++:symbol {
            .name = "demo_func";
            .kind = "function";
            .signature = "demo_func(x: int) -> int";
            .start_line = 1;
            .end_line = 3;
            .docstring = "Demo function for smoke test.";
        }
        connect(f, sym, file_contains_symbol);

        with t = spawn proj ++:task {
            .id = gen_uuid();
            .created_at = now();
            .user_prompt = "Run demo seed";
            .project_id = proj.id;
            .status = "running";
            .tags = ["demo", "seed"];
        }

        with s = spawn t ++:step {
            .id = gen_uuid();
            .order = 1;
            .role = "testing";
            .llm_summary = "Seeded demo project";
        }
        connect(t, s, task_has_step);

        with tool = spawn s ++:tool_invocation {
            .id = gen_uuid();
            .tool_name = "echo";
            .params_json = "{\\"message\\": \\\"hello\\\"}";
            .started_at = now();
            .duration_ms = 10;
            .success = true;
            .stdout = "hello";
            .stderr = "";
        }
        connect(s, tool, step_invokes_tool);
        connect(tool, f, tool_touches_file);

        report {"project_id": proj.id, "task_id": t.id, "file": f.path};
    }
}

// --- Production walkers wired to the MCP backend ---

walker ingest_project_graph {
    has project_root: str;
    has mode: str;
    has files: list[dict];

    root {
        assert project_root, "project_root is required";
        with proj = here-->project(root_path=project_root) {
            proj.project_id = proj.id;
        } else {
            with proj = spawn here ++:project {
                .id = digest(project_root);
                .project_id = .id;
                .root_path = project_root;
            }
        }

        if mode == "full" {
            // Reset file/directory contents for a fresh crawl
            for d in proj->project_contains_dir {
                destroy(d);
            }
        }

        for fdict in files {
            with dir_node = proj-->project_contains_dir(path=fdict.directory) {
                // reuse existing directory
            } else {
                with dir_node = spawn proj ++:directory {
                    .path = fdict.directory;
                }
                connect(proj, dir_node, project_contains_dir);
            }

            with f = dir_node-->dir_contains_file(path=fdict.path) {
                // update metadata below
            } else {
                with f = spawn dir_node ++:file {
                    .path = fdict.path;
                }
                connect(dir_node, f, dir_contains_file);
            }

            f.language = fdict.language if has_attr(fdict, "language") else "unknown";
            f.size_bytes = fdict.size_bytes if has_attr(fdict, "size_bytes") else 0;
            f.hash = fdict.hash if has_attr(fdict, "hash") else "";
            f.last_modified = fdict.last_modified if has_attr(fdict, "last_modified") else now();
        }

        report {"files_indexed": len(files), "project_id": proj.id};
    }
}

walker record_etg_event {
    has project_root: str;
    has task_id: str;
    has kind: str;
    has payload: dict;

    root {
        assert project_root, "project_root is required";
        with proj = here-->project(root_path=project_root) {
        } else {
            fail "Project not indexed";
        }

        if not task_id {
            task_id = gen_uuid();
        }

        with task_node = proj-->task(id=task_id) {
        } else {
            with task_node = spawn proj ++:task {
                .id = task_id;
                .created_at = payload.get("created_at", now());
                .user_prompt = payload.get("user_prompt", "");
                .project_id = proj.id;
                .status = payload.get("status", "running");
                .tags = payload.get("tags", []);
            }
        }

        step_id = null;
        tool_id = null;

        if kind == "step" {
            with step_node = spawn task_node ++:step {
                .id = gen_uuid();
                .order = payload.get("order", len(task_node->task_has_step) + 1);
                .role = payload.get("role", "");
                .llm_summary = payload.get("llm_summary", "");
            }
            connect(task_node, step_node, task_has_step);
            step_id = step_node.id;
        } elif kind == "tool_start" {
            with step_node = ensure_step(task_node, payload) {
            }
            with tool_node = spawn step_node ++:tool_invocation {
                .id = gen_uuid();
                .tool_name = payload.get("tool_name", "");
                .params_json = payload.get("params_json", "{}");
                .started_at = payload.get("started_at", now());
                .success = null;
            }
            connect(step_node, tool_node, step_invokes_tool);
            tool_id = tool_node.id;
            step_id = step_node.id;
            attach_files(tool_node, payload.get("files_touched", []));
        } elif kind == "tool_end" {
            with tool_node = find_tool(task_node) {
                tool_node.success = payload.get("success", true);
                tool_node.duration_ms = payload.get("duration_ms", 0);
                tool_node.stdout = payload.get("stdout", "");
                tool_node.stderr = payload.get("stderr", "");
                tool_id = tool_node.id;
                step_id = (tool_node<-step_invokes_tool).id if tool_node<-step_invokes_tool else null;
                attach_files(tool_node, payload.get("files_touched", []));
            }
        } elif kind == "checkpoint" {
            with step_node = ensure_step(task_node, payload) {
                with cp = spawn step_node ++:checkpoint_node {
                    .id = gen_uuid();
                    .checkpoint_file = payload.get("checkpoint_file", "");
                    .created_at = payload.get("created_at", now());
                }
                connect(step_node, cp, step_has_checkpoint);
                step_id = step_node.id;
            }
        } elif kind == "error" {
            with step_node = ensure_step(task_node, payload) {
                with err = spawn step_node ++:error {
                    .id = gen_uuid();
                    .error_type = payload.get("error_type", "runtime_error");
                    .message = payload.get("message", "");
                    .raw_log_excerpt = payload.get("raw_log_excerpt", "");
                }
                connect(step_node, err, step_has_error);
                step_id = step_node.id;
            }
        } elif kind == "task_end" {
            task_node.status = payload.get("status", "completed");
        } else {
            // task_start or default: ensure task exists and tags are updated
            task_node.tags = payload.get("tags", task_node.tags);
        }

        report {"task_id": task_id, "step_id": step_id, "tool_id": tool_id};
    }

    can ensure_step(t: node, payload: dict) -> node {
        if t->task_has_step {
            return t->task_has_step[-1];
        }
        with s = spawn t ++:step {
            .id = gen_uuid();
            .order = payload.get("order", 1);
            .role = payload.get("role", "");
            .llm_summary = payload.get("llm_summary", "");
        }
        connect(t, s, task_has_step);
        return s;
    }

    can attach_files(tool_node: node, files: list[str]) -> None {
        for fpath in files {
            with f = here-->file(path=fpath) {
                // attach existing file
            } else {
                continue;
            }
            connect(tool_node, f, tool_touches_file);
        }
    }

    can find_tool(t: node) -> node {
        if t->task_has_step {
            for s in reversed(t->task_has_step) {
                if s->step_invokes_tool {
                    return s->step_invokes_tool[-1];
                }
            }
        }
        with dummy = spawn t ++:tool_invocation { .id = gen_uuid(); .tool_name = "unknown"; }
        return dummy;
    }
}

walker query_similar_attempts {
    has project_root: str;
    has query: str;
    has file_paths: list[str];
    has limit: int;

    root {
        with proj = here-->project(root_path=project_root) {
            candidates = [];
            q = lower(query);

            for s in proj-->task_has_step {
                task = s<-task_has_step;
                files = [f.path for f in s->tool_invokes_tool->tool_touches_file];
                if file_paths and not intersection(files, file_paths) {
                    continue;
                }
                summary_text = task.user_prompt + "\n" + s.llm_summary + "\n" + " ".join(files);
                score = count(summary_text, q);
                if score > 0 {
                    candidates.append({
                        "step_id": s.id,
                        "task_id": task.id,
                        "score": score,
                        "user_prompt": task.user_prompt,
                        "llm_summary": s.llm_summary,
                        "files": files,
                        "errors": [e.id for e in s->step_has_error],
                    });
                }
            }

            // sort by score descending
            candidates.sort(key=lambda c: -c.score);
            results = candidates[:limit];
            summary_lines = [];
            for idx, r in enumerate(results) {
                summary_lines.append("- Step " + str(idx + 1) + " (task " + r.task_id + "): score=" + str(r.score));
            }
            summary_markdown = "\n".join(summary_lines) if summary_lines else "No similar attempts found.";
            report {"results": results, "summary_markdown": summary_markdown};
        }
    }
}

walker context_for_files {
    has project_root: str;
    has file_paths: list[str];
    has radius: int;

    root {
        with proj = here-->project(root_path=project_root) {
            normalized = set(file_paths);
            context_files = {};
            steps = [];
            for f in proj-->dir_contains_file {
                if f.path in normalized {
                    context_files[f.path] = {
                        "path": f.path,
                        "language": f.language,
                        "size_bytes": f.size_bytes,
                        "hash": f.hash,
                        "last_modified": f.last_modified,
                    };
                    for tool in f<-tool_touches_file {
                        step_node = tool<-step_invokes_tool;
                        steps.append({
                            "task_id": step_node<-task_has_step.id,
                            "step_id": step_node.id,
                            "llm_summary": step_node.llm_summary,
                            "files_touched": [ff.path for ff in tool->tool_touches_file],
                        });
                    }
                }
            }

            lines = ["### Graph context", "Files:"];
            for path, meta in context_files.items() {
                lines.append("- " + path + " (size=" + str(meta.size_bytes) + ", lang=" + meta.language + ")");
            }
            if steps {
                lines.append("\n### Recent ETG steps");
                for s in steps {
                    lines.append("- Task " + s.task_id + " step " + s.step_id + ": " + s.llm_summary);
                }
            }

            report {"context_pack": {"files": context_files, "symbols": {}, "concepts": {}, "etg_steps": steps, "radius": radius}, "returnDisplay": "\n".join(lines)};
        }
    }
}
