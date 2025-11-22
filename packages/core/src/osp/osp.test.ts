/**
 * @license
 * Copyright 2025 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import crypto from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const __filename = fileURLToPath(import.meta.url);
const jacDir = path.dirname(__filename);

function sha1(value: string): string {
  return crypto.createHash('sha1').update(value).digest('hex');
}

type NodeKind =
  | 'project'
  | 'directory'
  | 'file'
  | 'symbol'
  | 'concept'
  | 'task'
  | 'step'
  | 'tool_invocation'
  | 'checkpoint_node'
  | 'error';

interface NodeRecord {
  id: string;
  type: NodeKind;
  props: Record<string, unknown>;
}

interface EdgeRecord {
  type: string;
  from: string;
  to: string;
}

class MemoryGraph {
  nodes = new Map<string, NodeRecord>();
  edges: EdgeRecord[] = [];

  upsertNode(type: NodeKind, id: string, props: Record<string, unknown>): NodeRecord {
    const existing = this.nodes.get(id);
    if (existing) {
      Object.assign(existing.props, props);
      return existing;
    }
    const created: NodeRecord = { id, type, props: { ...props } };
    this.nodes.set(id, created);
    return created;
  }

  connect(type: string, from: string, to: string): void {
    if (!this.edges.find((edge) => edge.type === type && edge.from === from && edge.to === to)) {
      this.edges.push({ type, from, to });
    }
  }

  findNodes(type: NodeKind): NodeRecord[] {
    return Array.from(this.nodes.values()).filter((node) => node.type === type);
  }

  getNode(id: string): NodeRecord | undefined {
    return this.nodes.get(id);
  }
}

class IdFactory {
  private counters: Record<string, number> = {};

  next(prefix: string): string {
    this.counters[prefix] = (this.counters[prefix] || 0) + 1;
    return `${prefix}-${this.counters[prefix]}`;
  }
}

interface ConceptSpec {
  label: string;
  description: string;
  source: string;
}

interface SymbolSpec {
  name: string;
  kind: string;
  signature: string;
  span_start_line: number;
  span_end_line: number;
  docstring?: string;
  concepts?: ConceptSpec[];
}

interface FileSpec {
  path: string;
  language: string;
  size_bytes: number;
  last_modified: string;
  symbols?: SymbolSpec[];
}

interface IndexStats {
  files_indexed: number;
  symbols_indexed: number;
  concepts_indexed: number;
  duration_ms: number;
}

function normalizeDir(value: string): string {
  const normalized = path.posix.normalize(value);
  return normalized.endsWith('/') ? normalized.slice(0, -1) : normalized;
}

function indexProjectMock(
  graph: MemoryGraph,
  projectRoot: string,
  files: FileSpec[],
): IndexStats {
  const start = Date.now();
  const projectId = sha1(projectRoot);
  graph.upsertNode('project', projectId, { root_path: projectRoot, id: projectId });

  const dirSet = new Set<string>();
  for (const file of files) {
    let current = normalizeDir(path.posix.dirname(file.path));
    while (current.startsWith(projectRoot)) {
      dirSet.add(current);
      const parent = normalizeDir(path.posix.dirname(current));
      if (parent === current || parent.length < projectRoot.length) {
        break;
      }
      current = parent;
    }
  }

  for (const dir of dirSet) {
    graph.upsertNode('directory', dir, { path: dir });
    graph.connect('project_contains_dir', projectId, dir);
    const parent = normalizeDir(path.posix.dirname(dir));
    if (dir !== parent && dirSet.has(parent)) {
      graph.connect('dir_contains_dir', parent, dir);
    }
  }

  let symbolsIndexed = 0;
  let conceptsIndexed = 0;
  for (const file of files) {
    const fileId = file.path;
    graph.upsertNode('file', fileId, {
      path: file.path,
      language: file.language,
      size_bytes: file.size_bytes,
      hash: sha1(file.path + file.size_bytes.toString()),
      last_modified: file.last_modified,
    });
    graph.connect('dir_contains_file', normalizeDir(path.posix.dirname(file.path)), fileId);

    for (const symbol of file.symbols || []) {
      const symbolId = `${file.path}::${symbol.name}`;
      graph.upsertNode('symbol', symbolId, {
        name: symbol.name,
        kind: symbol.kind,
        signature: symbol.signature,
        span_start_line: symbol.span_start_line,
        span_end_line: symbol.span_end_line,
        docstring: symbol.docstring ?? '',
      });
      graph.connect('file_contains_symbol', fileId, symbolId);
      symbolsIndexed += 1;

      for (const concept of symbol.concepts || []) {
        const conceptId = concept.label;
        graph.upsertNode('concept', conceptId, concept);
        graph.connect('symbol_implements_concept', symbolId, conceptId);
        conceptsIndexed += 1;
      }
    }
  }

  return {
    files_indexed: files.length,
    symbols_indexed: symbolsIndexed,
    concepts_indexed: conceptsIndexed,
    duration_ms: Date.now() - start,
  };
}

interface LogEventParams {
  project_root: string;
  task_id?: string;
  kind:
    | 'task_start'
    | 'step'
    | 'tool_start'
    | 'tool_end'
    | 'checkpoint'
    | 'error'
    | 'task_end';
  payload: Record<string, any>;
}

interface LogEventResponse {
  task_id: string;
  step_id: string | null;
  tool_id: string | null;
}

function latestStep(graph: MemoryGraph, taskId: string): NodeRecord | undefined {
  const stepEdges = graph.edges.filter((edge) => edge.type === 'task_has_step' && edge.from === taskId);
  const steps = stepEdges
    .map((edge) => graph.getNode(edge.to))
    .filter((node): node is NodeRecord => Boolean(node))
    .sort((a, b) => Number(b.props.order || 0) - Number(a.props.order || 0));
  return steps[0];
}

function latestTool(graph: MemoryGraph, stepId: string, toolName: string): NodeRecord | undefined {
  const toolEdges = graph.edges.filter(
    (edge) => edge.type === 'step_invokes_tool' && edge.from === stepId,
  );
  const tools = toolEdges
    .map((edge) => graph.getNode(edge.to))
    .filter((node): node is NodeRecord => Boolean(node))
    .filter((node) => (node.props.tool_name as string) === toolName);
  return tools.at(-1);
}

function logEventMock(
  graph: MemoryGraph,
  ids: IdFactory,
  { project_root: projectRoot, task_id: providedTaskId, kind, payload }: LogEventParams,
): LogEventResponse {
  const projectId = sha1(projectRoot);
  graph.upsertNode('project', projectId, { root_path: projectRoot, id: projectId });
  let taskId = providedTaskId;

  if (kind === 'task_start') {
    taskId = payload.task_id ?? ids.next('task');
    graph.upsertNode('task', taskId, {
      id: taskId,
      created_at: payload.created_at ?? new Date().toISOString(),
      user_prompt: payload.user_prompt,
      project_id: projectId,
      status: 'running',
      tags: payload.tags ?? [],
      files_touched: [],
      embedding: [],
    });
    return { task_id: taskId, step_id: null, tool_id: null };
  }

  if (!taskId) {
    throw new Error('task_id is required for this event');
  }

  if (kind === 'step') {
    const stepId = payload.step_id ?? ids.next('step');
    graph.upsertNode('step', stepId, {
      id: stepId,
      order: payload.order,
      role: payload.role ?? '',
      llm_summary: payload.llm_summary ?? '',
      files_touched: payload.files_touched ?? [],
      embedding: [],
    });
    graph.connect('task_has_step', taskId, stepId);
    return { task_id: taskId, step_id: stepId, tool_id: null };
  }

  if (kind === 'tool_start') {
    const step = latestStep(graph, taskId);
    if (!step) throw new Error('step must exist before tool_start');
    const toolId = ids.next('tool');
    graph.upsertNode('tool_invocation', toolId, {
      id: toolId,
      tool_name: payload.tool_name,
      params_json: payload.params_json ?? {},
      started_at: payload.started_at ?? new Date().toISOString(),
      files_touched: payload.files_touched ?? [],
    });
    graph.connect('step_invokes_tool', step.id, toolId);
    for (const f of payload.files_touched ?? []) {
      graph.connect('tool_touches_file', toolId, f);
    }
    return { task_id: taskId, step_id: step.id, tool_id: toolId };
  }

  if (kind === 'tool_end') {
    const step = latestStep(graph, taskId);
    if (!step) throw new Error('step must exist before tool_end');
    const tool = latestTool(graph, step.id, payload.tool_name);
    const toolId = tool?.id ?? ids.next('tool');
    graph.upsertNode('tool_invocation', toolId, {
      ...(tool?.props ?? {}),
      id: toolId,
      tool_name: payload.tool_name,
      success: payload.success,
      duration_ms: payload.duration_ms ?? 0,
      stdout: payload.stdout ?? '',
      stderr: payload.stderr ?? '',
      files_touched: payload.files_touched ?? tool?.props.files_touched ?? [],
    });
    graph.connect('step_invokes_tool', step.id, toolId);
    for (const f of (payload.files_touched ?? tool?.props.files_touched ?? []) as string[]) {
      graph.connect('tool_touches_file', toolId, f);
    }
    return { task_id: taskId, step_id: step.id, tool_id: toolId };
  }

  if (kind === 'checkpoint') {
    const step = latestStep(graph, taskId);
    if (!step) throw new Error('step must exist before checkpoint');
    const checkpointId = ids.next('checkpoint');
    graph.upsertNode('checkpoint_node', checkpointId, {
      id: checkpointId,
      checkpoint_file: payload.checkpoint_file,
      created_at: payload.created_at ?? new Date().toISOString(),
    });
    graph.connect('step_has_checkpoint', step.id, checkpointId);
    return { task_id: taskId, step_id: step.id, tool_id: null };
  }

  if (kind === 'error') {
    const step = latestStep(graph, taskId);
    if (!step) throw new Error('step must exist before error');
    const errorId = ids.next('error');
    graph.upsertNode('error', errorId, {
      id: errorId,
      error_type: payload.error_type,
      message: payload.message,
      raw_log_excerpt: payload.raw_log_excerpt ?? '',
    });
    graph.connect('step_has_error', step.id, errorId);
    return { task_id: taskId, step_id: step.id, tool_id: null };
  }

  if (kind === 'task_end') {
    graph.upsertNode('task', taskId, { status: payload.status });
    return { task_id: taskId, step_id: null, tool_id: null };
  }

  throw new Error(`Unhandled kind ${kind}`);
}

function overlap(a: string[], b: string[]): boolean {
  return a.some((item) => b.includes(item));
}

function similarAttemptsMock(
  graph: MemoryGraph,
  projectRoot: string,
  query: string,
  filePaths: string[] | null,
  limit: number,
) {
  const projectId = sha1(projectRoot);
  graph.upsertNode('project', projectId, { root_path: projectRoot, id: projectId });
  const steps = graph.findNodes('step');
  const scored = steps.map((step) => {
    const summary = (step.props.llm_summary as string) ?? '';
    const files = (step.props.files_touched as string[]) ?? [];
    let score = 0;
    if (query && summary.toLowerCase().includes(query.toLowerCase())) score += 1;
    if (filePaths && overlap(files, filePaths)) score += 1;
    score += Math.min(files.length, 3) * 0.1;
    return {
      step_id: step.id,
      task_id:
        graph.edges.find((edge) => edge.type === 'task_has_step' && edge.to === step.id)?.from || '',
      files,
      llm_summary: summary,
      score,
    };
  });

  const results = scored.sort((a, b) => b.score - a.score).slice(0, limit);
  const summaryMarkdown = results
    .map((result, index) => `${index + 1}. Step ${result.step_id} (${result.files.join(', ')}) score=${result.score}`)
    .join('\n');
  return { results, summary_markdown: summaryMarkdown };
}

function contextForFilesMock(
  graph: MemoryGraph,
  projectRoot: string,
  filePaths: string[],
  radius: number,
) {
  const projectId = sha1(projectRoot);
  graph.upsertNode('project', projectId, { root_path: projectRoot, id: projectId });
  const symbols: NodeRecord[] = [];
  const concepts: NodeRecord[] = [];
  for (const file of filePaths) {
    const symbolEdges = graph.edges.filter(
      (edge) => edge.type === 'file_contains_symbol' && edge.from === file,
    );
    for (const edge of symbolEdges) {
      const symbolNode = graph.getNode(edge.to);
      if (symbolNode) {
        symbols.push(symbolNode);
      }
    }
  }

  for (const symbol of symbols) {
    const conceptEdges = graph.edges.filter(
      (edge) => edge.type === 'symbol_implements_concept' && edge.from === symbol.id,
    );
    for (const edge of conceptEdges) {
      const conceptNode = graph.getNode(edge.to);
      if (conceptNode && !concepts.find((c) => c.id === conceptNode.id)) {
        concepts.push(conceptNode);
      }
    }
  }

  const steps = graph.findNodes('step').filter((step) => {
    const files = (step.props.files_touched as string[]) ?? [];
    return overlap(files, filePaths);
  });

  const returnDisplay = `Context for ${filePaths.join(', ')}\nSymbols: ${symbols
    .map((s) => s.props.name)
    .join(', ')}\nConcepts: ${concepts.map((c) => c.props.label).join(', ')}\nSteps: ${steps
    .map((s) => s.id)
    .join(', ')}`;

  return {
    context_pack: {
      symbols,
      concepts,
      steps,
      files: filePaths,
      radius,
    },
    returnDisplay,
  };
}

const fixtureProjectRoot = '/workspace/demo';
const fixtureFiles: FileSpec[] = [
  {
    path: '/workspace/demo/src/main.ts',
    language: 'typescript',
    size_bytes: 32,
    last_modified: '2025-01-01T00:00:00Z',
    symbols: [
      {
        name: 'greet',
        kind: 'function',
        signature: 'function greet(name: string): string',
        span_start_line: 1,
        span_end_line: 3,
        docstring: 'Return a polite greeting.',
        concepts: [
          { label: 'greeting', description: 'Polite acknowledgements', source: 'manual' },
        ],
      },
    ],
  },
  {
    path: '/workspace/demo/README.md',
    language: 'markdown',
    size_bytes: 18,
    last_modified: '2025-01-01T00:00:00Z',
    symbols: [],
  },
];

describe('Jac OSP implementation scaffolding', () => {
  it('documents the node and walker surfaces from the interface freeze', () => {
    const nodesJac = readFileSync(path.join(jacDir, 'nodes.jac'), 'utf8');
    const walkersJac = readFileSync(path.join(jacDir, 'walkers.jac'), 'utf8');

    expect(nodesJac).toContain('node project');
    expect(nodesJac).toContain('node task');
    expect(nodesJac).toContain('edge tool_touches_file');
    expect(walkersJac).toContain('walker IndexProject');
    expect(walkersJac).toContain('walker LogEvent');
    expect(walkersJac).toContain('walker SimilarAttempts');
    expect(walkersJac).toContain('walker ContextForFiles');
  });

  it('indexes a simple project graph in line with the IndexProject walker', () => {
    const graph = new MemoryGraph();
    const stats = indexProjectMock(graph, fixtureProjectRoot, fixtureFiles);

    expect(stats.files_indexed).toBe(2);
    expect(stats.symbols_indexed).toBe(1);
    expect(stats.concepts_indexed).toBe(1);

    const project = graph.findNodes('project')[0];
    expect(project.props.root_path).toBe(fixtureProjectRoot);

    const directories = graph.findNodes('directory').map((node) => node.props.path);
    expect(directories).toContain('/workspace/demo');
    expect(directories).toContain('/workspace/demo/src');

    const fileEdges = graph.edges.filter((edge) => edge.type === 'dir_contains_file');
    expect(fileEdges.map((edge) => edge.to)).toContain('/workspace/demo/src/main.ts');

    const symbolEdges = graph.edges.filter((edge) => edge.type === 'file_contains_symbol');
    expect(symbolEdges[0]?.from).toBe('/workspace/demo/src/main.ts');
  });

  it('creates an ETG trace through the LogEvent walker flow', () => {
    const graph = new MemoryGraph();
    const ids = new IdFactory();
    indexProjectMock(graph, fixtureProjectRoot, fixtureFiles);

    const start = logEventMock(graph, ids, {
      project_root: fixtureProjectRoot,
      kind: 'task_start',
      payload: { user_prompt: 'Improve greeting', tags: ['demo'] },
    });
    const step = logEventMock(graph, ids, {
      project_root: fixtureProjectRoot,
      task_id: start.task_id,
      kind: 'step',
      payload: {
        order: 1,
        role: 'editing',
        llm_summary: 'Update greet output',
        files_touched: ['/workspace/demo/src/main.ts'],
      },
    });
    const toolStart = logEventMock(graph, ids, {
      project_root: fixtureProjectRoot,
      task_id: start.task_id,
      kind: 'tool_start',
      payload: {
        tool_name: 'apply_patch',
        params_json: { patch: '+++ greet' },
        files_touched: ['/workspace/demo/src/main.ts'],
      },
    });
    const toolEnd = logEventMock(graph, ids, {
      project_root: fixtureProjectRoot,
      task_id: start.task_id,
      kind: 'tool_end',
      payload: {
        tool_name: 'apply_patch',
        success: true,
        duration_ms: 42,
        stdout: 'patched',
        files_touched: ['/workspace/demo/src/main.ts'],
      },
    });
    logEventMock(graph, ids, {
      project_root: fixtureProjectRoot,
      task_id: start.task_id,
      kind: 'checkpoint',
      payload: { checkpoint_file: '/workspace/demo/.checkpoints/1.json' },
    });
    logEventMock(graph, ids, {
      project_root: fixtureProjectRoot,
      task_id: start.task_id,
      kind: 'error',
      payload: {
        error_type: 'test_failure',
        message: 'Tests failed',
        raw_log_excerpt: 'npm test failed',
      },
    });
    logEventMock(graph, ids, {
      project_root: fixtureProjectRoot,
      task_id: start.task_id,
      kind: 'task_end',
      payload: { status: 'failed' },
    });

    expect(start.tool_id).toBeNull();
    expect(step.step_id).toBeTruthy();
    expect(toolStart.tool_id).toBeTruthy();
    expect(toolEnd.tool_id).toBeTruthy();

    const task = graph.getNode(start.task_id);
    expect(task?.type).toBe('task');
    expect(graph.edges.filter((edge) => edge.type === 'task_has_step').length).toBe(1);
    expect(graph.edges.filter((edge) => edge.type === 'step_invokes_tool').length).toBe(1);
    expect(graph.edges.filter((edge) => edge.type === 'step_has_checkpoint').length).toBe(1);
    expect(graph.edges.filter((edge) => edge.type === 'step_has_error').length).toBe(1);

    const similar = similarAttemptsMock(
      graph,
      fixtureProjectRoot,
      'greet',
      ['/workspace/demo/src/main.ts'],
      5,
    );
    expect(similar.results[0]?.files).toContain('/workspace/demo/src/main.ts');

    const context = contextForFilesMock(
      graph,
      fixtureProjectRoot,
      ['/workspace/demo/src/main.ts'],
      1,
    );
    expect(context.context_pack.symbols[0]?.props.name).toBe('greet');
    expect(context.returnDisplay).toContain('Context for /workspace/demo/src/main.ts');
  });
});
