/**
 * @license
 * Copyright 2025 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import type { Content } from '@google/genai';
import { partToString } from './partUtils.js';
import type { Config } from '../config/config.js';
import type { ToolResult } from '../tools/tools.js';

type EtgEventKind =
  | 'task_start'
  | 'step'
  | 'tool_start'
  | 'tool_end'
  | 'checkpoint'
  | 'error'
  | 'task_end';

type EtgState = {
  taskId?: string;
  stepId?: string;
  toolId?: string;
  filesTouched: Set<string>;
};

const etgState = new WeakMap<Config, EtgState>();

function getState(config: Config): EtgState {
  const existing = etgState.get(config);
  if (existing) return existing;
  const created: EtgState = { filesTouched: new Set() };
  etgState.set(config, created);
  return created;
}

function getProjectRoot(config: Config): string | undefined {
  return config.getProjectRoot?.() ?? config.getTargetDir?.();
}

function getEtgTool(config: Config, name: string) {
  const tool = config.getToolRegistry().getTool(name);
  if (!tool) return undefined;
  return tool;
}

async function callEtgTool(
  config: Config,
  toolName: string,
  params: Record<string, unknown>,
): Promise<ToolResult | undefined> {
  const tool = getEtgTool(config, toolName);
  if (!tool) return undefined;
  const invocation = tool.createInvocation(params);
  const controller = new AbortController();
  const result = await invocation.execute(controller.signal);
  return result;
}

function parseStructuredResponse(result: ToolResult | undefined):
  | Record<string, unknown>
  | undefined {
  if (!result) return undefined;
  const text = partToString(result.llmContent);
  try {
    return JSON.parse(text);
  } catch (error) {
    return undefined;
  }
}

function updateStateFromPayload(state: EtgState, payload: Record<string, unknown>) {
  const files = (payload['files_touched'] as string[] | undefined) ?? [];
  files.forEach((file) => state.filesTouched.add(file));
}

export async function logEtgEvent(
  config: Config,
  kind: EtgEventKind,
  payload: Record<string, unknown>,
): Promise<void> {
  const projectRoot = getProjectRoot(config);
  if (!projectRoot) return;

  const state = getState(config);
  const params: Record<string, unknown> = {
    project_root: projectRoot,
    task_id: state.taskId ?? null,
    kind,
    payload: { ...payload },
  };

  if (kind === 'tool_end' && !params.payload['tool_id'] && state.toolId) {
    params.payload['tool_id'] = state.toolId;
  }

  updateStateFromPayload(state, params.payload as Record<string, unknown>);

  const result = await callEtgTool(config, 'jaseci-etg__etg_log_event', params);
  const structured = parseStructuredResponse(result);

  state.taskId = (structured?.['task_id'] as string | undefined) ?? state.taskId;
  state.stepId = (structured?.['step_id'] as string | undefined) ?? state.stepId;

  if (kind === 'tool_start') {
    state.toolId = structured?.['tool_id'] as string | undefined;
  }
  if (kind === 'tool_end') {
    state.toolId = undefined;
  }
}

export function getEtgFiles(config: Config): string[] {
  return Array.from(getState(config).filesTouched);
}

function combineContextSummaries(
  similarAttempts: ToolResult | undefined,
  fileContext: ToolResult | undefined,
): string | null {
  const parts: string[] = [];
  if (similarAttempts) {
    parts.push(partToString(similarAttempts.llmContent));
  }
  if (fileContext) {
    parts.push(partToString(fileContext.llmContent));
  }
  if (parts.length === 0) return null;
  return parts.join('\n\n');
}

export async function buildEtgContextContent(
  config: Config,
  query: string,
  filePaths: string[],
): Promise<Content | null> {
  const projectRoot = getProjectRoot(config);
  if (!projectRoot) return null;

  const similarAttempts = await callEtgTool(
    config,
    'jaseci-etg__etg_query_similar_attempts',
    {
      project_root: projectRoot,
      query,
      file_paths: filePaths.length > 0 ? filePaths : null,
      limit: 5,
    },
  );

  const contextForFiles = filePaths.length
    ? await callEtgTool(config, 'jaseci-etg__graph_context_for_files', {
        project_root: projectRoot,
        file_paths: filePaths,
        radius: 1,
      })
    : undefined;

  const summary = combineContextSummaries(similarAttempts, contextForFiles);

  if (!summary) return null;

  return {
    role: 'system',
    parts: [
      {
        text: `Relevant past attempts and context:\n${summary}`,
      },
    ],
  };
}

export async function attachEtgContextToHistory(
  config: Config,
  history: Content[],
  query: string,
  filePaths?: string[],
): Promise<void> {
  const files = filePaths ?? getEtgFiles(config);
  const content = await buildEtgContextContent(config, query, files);
  if (content) {
    history.push(content);
  }
}
