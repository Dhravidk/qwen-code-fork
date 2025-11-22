/**
 * @license
 * Copyright 2025 Google LLC
 * SPDX-License-Identifier: Apache-2.0
 */

import type { Content } from '@google/genai';
import { describe, expect, it, vi } from 'vitest';
import { CoreToolScheduler } from './coreToolScheduler.js';
import { ApprovalMode, DEFAULT_TRUNCATE_TOOL_OUTPUT_LINES, DEFAULT_TRUNCATE_TOOL_OUTPUT_THRESHOLD } from '../config/config.js';
import { MockTool } from '../test-utils/mock-tool.js';
import { attachEtgContextToHistory } from '../utils/etgIntegration.js';
import { ToolRegistry } from '../tools/tool-registry.js';
import { PromptRegistry } from '../prompts/prompt-registry.js';
import type { Config } from '../config/config.js';
import { WorkspaceContext } from '../utils/workspaceContext.js';

function createTestConfig(): Config {
  const promptRegistry = new PromptRegistry();
  const workspaceContext = new WorkspaceContext('/project');
  const stubConfig: Partial<Config> = {
    getSessionId: () => 'session',
    getUsageStatisticsEnabled: () => true,
    getDebugMode: () => false,
    getApprovalMode: () => ApprovalMode.DEFAULT,
    getAllowedTools: () => [],
    getContentGeneratorConfig: () => ({
      model: 'test-model',
      authType: 'oauth-personal',
    }),
    getShellExecutionConfig: () => ({ terminalWidth: 80, terminalHeight: 24 }),
    storage: { getProjectTempDir: () => '/tmp' } as Config['storage'],
    getTruncateToolOutputThreshold: () => DEFAULT_TRUNCATE_TOOL_OUTPUT_THRESHOLD,
    getTruncateToolOutputLines: () => DEFAULT_TRUNCATE_TOOL_OUTPUT_LINES,
    getUseSmartEdit: () => false,
    getUseModelRouter: () => false,
    getGeminiClient: () => null,
    getProjectRoot: () => '/project',
    getWorkspaceContext: () => workspaceContext,
    getPromptRegistry: () => promptRegistry,
    getMcpServers: () => ({}),
    getMcpServerCommand: () => undefined,
  };

  const toolRegistry = new ToolRegistry(stubConfig as Config);
  (stubConfig as Config).getToolRegistry = () => toolRegistry;
  return stubConfig as Config;
}

describe('ETG integration', () => {
  it('emits ETG tool_start and tool_end events around tool execution', async () => {
    const logCalls: Record<string, unknown>[] = [];
    const etgLogTool = new MockTool({
      name: 'jaseci-etg__etg_log_event',
      execute: async (params) => {
        logCalls.push(params);
        return {
          llmContent: JSON.stringify({
            task_id: 'task-1',
            step_id: 'step-1',
            tool_id: 'tool-1',
          }),
          returnDisplay: 'logged',
        };
      },
    });

    const primaryTool = new MockTool({
      name: 'echo-tool',
      execute: async () => ({
        llmContent: 'ok',
        returnDisplay: 'ok',
      }),
    });

    const config = createTestConfig();
    config.getToolRegistry().registerTool(etgLogTool);
    config.getToolRegistry().registerTool(primaryTool);

    await new Promise<void>((resolve) => {
      const scheduler = new CoreToolScheduler({
        config,
        onAllToolCallsComplete: async () => resolve(),
        onToolCallsUpdate: () => {},
        getPreferredEditor: () => 'vscode',
        onEditorClose: vi.fn(),
      });

      const abortController = new AbortController();
      scheduler.schedule(
        {
          callId: '1',
          name: primaryTool.name,
          args: {},
          isClientInitiated: false,
          prompt_id: 'prompt-id',
        },
        abortController.signal,
      );
    });

    expect(logCalls).toHaveLength(2);
    expect(logCalls[0]['kind']).toBe('tool_start');
    expect(logCalls[1]['kind']).toBe('tool_end');
  });

  it('injects ETG retrieval summaries into the LLM context', async () => {
    const similarTool = new MockTool({
      name: 'jaseci-etg__etg_query_similar_attempts',
      execute: async () => ({
        llmContent: 'previous attempts summary',
        returnDisplay: 'prev',
      }),
    });

    const contextTool = new MockTool({
      name: 'jaseci-etg__graph_context_for_files',
      execute: async () => ({
        llmContent: 'graph context summary',
        returnDisplay: 'ctx',
      }),
    });

    const config = createTestConfig();
    config.getToolRegistry().registerTool(similarTool);
    config.getToolRegistry().registerTool(contextTool);

    const history: Content[] = [];
    await attachEtgContextToHistory(
      config,
      history,
      'fix the failing test',
      ['/project/src/app.ts'],
    );

    expect(history).toHaveLength(1);
    expect(history[0].role).toBe('system');
    expect(history[0].parts[0].text).toContain('previous attempts summary');
    expect(history[0].parts[0].text).toContain('graph context summary');
  });
});
