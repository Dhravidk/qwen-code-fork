// Core node and edge schema for the Qwen Code ETG + Code Graph
// Follows Phase 0 schema in docs/INTERFACES.md

node project {
    /*
    Represents a single project/repository root.
    - id: stable hash/id for persistent storage.
    - root_path: absolute path to repo root.
    - project_id: optional alias for downstream tools that expect it.
    */
    has id: str;
    has root_path: str;
    has project_id: str;
}

node directory {
    /* Filesystem directory within a project. */
    has path: str;
}

node file {
    /* File metadata for indexing + retrieval. */
    has path: str;
    has language: str;
    has size_bytes: int;
    has hash: str;
    has last_modified: str;
}

node symbol {
    /* Source-level symbol: function, class, component, etc. */
    has name: str;
    has kind: str; // function|class|method|component|test|route|config|other
    has signature: str;
    has start_line: int;
    has end_line: int;
    has docstring: str;
}

node concept {
    /* Abstract idea linked to code (issue, TODO, etc.). */
    has label: str;
    has description: str;
    has source: str; // issue|todo|commit|manual|llm
}

// Execution Trace Graph (ETG) nodes
node task {
    has id: str;
    has created_at: str;
    has user_prompt: str;
    has project_id: str;
    has status: str; // planned|running|success|failed|aborted
    has tags: list[str];
}

node step {
    has id: str;
    has order: int;
    has role: str; // planning|reading|editing|testing|refactoring|docs
    has llm_summary: str;
}

node tool_invocation {
    has id: str;
    has tool_name: str;
    has params_json: str;
    has started_at: str;
    has duration_ms: int;
    has success: bool;
    has stdout: str;
    has stderr: str;
}

node checkpoint_node {
    has id: str;
    has checkpoint_file: str;
    has created_at: str;
}

node error {
    has id: str;
    has error_type: str; // test_failure|compile_error|tool_error|runtime_error
    has message: str;
    has raw_log_excerpt: str;
}

// Code graph edges
edge project_contains_dir: project -> directory;
edge dir_contains_dir: directory -> directory;
edge dir_contains_file: directory -> file;
edge file_contains_symbol: file -> symbol;
edge symbol_calls_symbol: symbol -> symbol;
edge symbol_tests_symbol: symbol -> symbol;
edge symbol_implements_concept: symbol -> concept;
edge file_mentions_concept: file -> concept;

// ETG edges
edge task_has_step: task -> step;
edge step_invokes_tool: step -> tool_invocation;
edge tool_touches_file: tool_invocation -> file;
edge step_has_checkpoint: step -> checkpoint_node;
edge step_has_error: step -> error;
edge step_depends_on_step: step -> step;
edge task_related_to_concept: task -> concept;
edge similar_step: step <-> step; // symmetric relationship
