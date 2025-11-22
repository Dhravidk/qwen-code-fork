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
