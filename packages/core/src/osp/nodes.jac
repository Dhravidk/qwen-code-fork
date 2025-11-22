# @license
# Copyright 2025 Google LLC
# SPDX-License-Identifier: Apache-2.0

# Execution Trace Graph (ETG) & Code Graph node and edge definitions
# These follow the schemas frozen in docs/INTERFACES.md for Phase 0.

node project {
    has id: str;
    has root_path: str;
}

node directory {
    has path: str;
}

node file {
    has path: str;
    has language: str;
    has size_bytes: int;
    has hash: str;
    has last_modified: str;
}

node symbol {
    has name: str;
    has kind: str; # function|class|method|component|test|route|config|other
    has signature: str;
    has span_start_line: int;
    has span_end_line: int;
    has docstring: str;
}

node concept {
    has label: str;
    has description: str;
    has source: str; # issue|todo|commit|manual|llm
}

node task {
    has id: str;
    has created_at: str;
    has user_prompt: str;
    has project_id: str;
    has status: str; # planned|running|success|failed|aborted
    has tags: list;
    has files_touched: list;
    has embedding: list;
}

node step {
    has id: str;
    has order: int;
    has role: str;
    has llm_summary: str;
    has files_touched: list;
    has embedding: list;
}

node tool_invocation {
    has id: str;
    has tool_name: str;
    has params_json: dict;
    has started_at: str;
    has duration_ms: int;
    has success: bool;
    has stdout: str;
    has stderr: str;
    has files_touched: list;
}

node checkpoint_node {
    has id: str;
    has checkpoint_file: str;
    has created_at: str;
}

node error {
    has id: str;
    has error_type: str;
    has message: str;
    has raw_log_excerpt: str;
}

# Code graph relations
edge project_contains_dir(project, directory);
edge dir_contains_dir(directory, directory);
edge dir_contains_file(directory, file);
edge file_contains_symbol(file, symbol);
edge symbol_calls_symbol(symbol, symbol);
edge symbol_tests_symbol(symbol, symbol);
edge symbol_implements_concept(symbol, concept);
edge file_mentions_concept(file, concept);

# ETG relations
edge task_has_step(task, step);
edge step_invokes_tool(step, tool_invocation);
edge tool_touches_file(tool_invocation, file);
edge step_has_checkpoint(step, checkpoint_node);
edge step_has_error(step, error);
edge step_depends_on_step(step, step);
edge task_related_to_concept(task, concept);
edge similar_step(step, step);
