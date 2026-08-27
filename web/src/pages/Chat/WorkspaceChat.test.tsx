import { fireEvent, render, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedbackProvider } from '@/components/ui';
import { RefreshProvider } from '@/store/refresh';
import WorkspaceChat from './WorkspaceChat';

const mocks = vi.hoisted(() => ({
  listProjects: vi.fn(),
  listAgentProjects: vi.fn(),
  listAgentTasks: vi.fn(),
  getAgentCapabilities: vi.fn(),
  getAgentTask: vi.fn(),
  createSession: vi.fn(),
  updateSessionMetadata: vi.fn(),
  deleteSession: vi.fn(),
  switchSession: vi.fn(),
  sendMessage: vi.fn(),
}));

vi.mock('@/api/projects', () => ({ listProjects: mocks.listProjects }));
vi.mock('@/api/sessions', () => ({
  listAgentProjects: mocks.listAgentProjects,
  listAgentTasks: mocks.listAgentTasks,
  getAgentCapabilities: mocks.getAgentCapabilities,
  getAgentTask: mocks.getAgentTask,
  createSession: mocks.createSession,
  updateSessionMetadata: mocks.updateSessionMetadata,
  deleteSession: mocks.deleteSession,
  switchSession: mocks.switchSession,
  sendMessage: mocks.sendMessage,
}));

const project = { id: 'project-1', name: '示例项目', path: '/repo', is_git_repository: true };
const task = { id: 'task-1', summary: '任务一', project_id: project.id, host_id: 'local', status: 'idle' };

function renderChat(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <FeedbackProvider>
        <RefreshProvider>
          <Routes>
            <Route path="/chat" element={<WorkspaceChat />} />
            <Route path="/chat/:projectId/new" element={<WorkspaceChat />} />
            <Route path="/chat/:projectId/:taskId" element={<WorkspaceChat />} />
          </Routes>
        </RefreshProvider>
      </FeedbackProvider>
    </MemoryRouter>,
  );
}

describe('Codex App 工作区聊天', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.listProjects.mockResolvedValue({ projects: [{ name: 'codex-app', agent_type: 'codexapp' }] });
    mocks.listAgentProjects.mockResolvedValue({ projects: [project] });
    mocks.listAgentTasks.mockResolvedValue({ sessions: [task], authoritative: true });
    mocks.getAgentCapabilities.mockResolvedValue({
      capabilities: {
        create: { supported: true }, rename: { supported: true }, pin: { supported: true },
        archive: { supported: true }, fork: { supported: true }, handoff: { supported: true },
        interactive_response: { supported: false, reason: '未开放' },
      },
    });
    mocks.getAgentTask.mockResolvedValue({
      session: task,
      history: [{ role: 'user', content: '现有消息', timestamp: '2026-08-27T01:00:00Z' }],
      has_more: false,
    });
    mocks.createSession.mockResolvedValue({ session: { ...task, id: 'task-2', status: 'active' }, session_key: 'web:management' });
    mocks.updateSessionMetadata.mockResolvedValue({});
    mocks.deleteSession.mockResolvedValue({});
    mocks.switchSession.mockResolvedValue({});
    mocks.sendMessage.mockResolvedValue({});
  });

  it('项目主点击只折叠和展开任务', async () => {
    const view = renderChat('/chat/project-1/task-1');
    expect(await view.findByText('现有消息')).toBeTruthy();
    const projectButton = view.getByRole('button', { name: '示例项目 展开任务' });
    fireEvent.click(projectButton);
    expect(view.queryByRole('button', { name: '打开任务 任务一' })).toBeNull();
    fireEvent.click(projectButton);
    expect(view.getByRole('button', { name: '打开任务 任务一' })).toBeTruthy();
  });

  it('任务通过显式省略号菜单执行元数据操作', async () => {
    const view = renderChat('/chat/project-1/task-1');
    await view.findByText('现有消息');
    fireEvent.click(view.getByRole('button', { name: '任务一 操作' }));
    fireEvent.click(view.getByRole('menuitem', { name: '置顶' }));
    await waitFor(() => expect(mocks.updateSessionMetadata).toHaveBeenCalledWith('codex-app', 'task-1', { pinned: true }, 'local'));
  });

  it('新建页首条消息只调用一次创建接口并携带 prompt', async () => {
    const view = renderChat('/chat/project-1/new');
    const input = await view.findByPlaceholderText('描述你要 Codex 完成的任务') as HTMLTextAreaElement;
    await waitFor(() => expect(input.disabled).toBe(false));
    fireEvent.change(input, { target: { value: '检查这个仓库' } });
    const send = view.getByRole('button', { name: '发送' }) as HTMLButtonElement;
    await waitFor(() => expect(send.disabled).toBe(false));
    fireEvent.click(send);
    await waitFor(() => expect(mocks.createSession).toHaveBeenCalledTimes(1));
    expect(mocks.createSession).toHaveBeenCalledWith('codex-app', {
      session_key: 'web:management',
      project_id: 'project-1',
      prompt: '检查这个仓库',
      use_local: true,
    });
    expect(mocks.sendMessage).not.toHaveBeenCalled();
  });

  it('继续任务时按 Runtime host 切换后再发送', async () => {
    const view = renderChat('/chat/project-1/task-1');
    const input = await view.findByPlaceholderText('给 Codex 发送消息') as HTMLTextAreaElement;
    await waitFor(() => expect(input.disabled).toBe(false));
    fireEvent.change(input, { target: { value: '继续检查' } });
    const send = view.getByRole('button', { name: '发送' }) as HTMLButtonElement;
    await waitFor(() => expect(send.disabled).toBe(false));
    fireEvent.click(send);
    await waitFor(() => expect(mocks.switchSession).toHaveBeenCalledWith('codex-app', {
      session_key: 'web:management',
      session_id: 'task-1',
      host_id: 'local',
    }));
    await waitFor(() => expect(mocks.sendMessage).toHaveBeenCalledWith('codex-app', {
      session_key: 'web:management',
      message: '继续检查',
    }));
  });

  it('App schema 缺少元数据能力时菜单明确禁用操作', async () => {
    mocks.getAgentCapabilities.mockResolvedValue({
      capabilities: {
        create: { supported: true }, rename: { supported: false, reason: '当前 App 不支持重命名' },
        pin: { supported: false, reason: '当前 App 不支持置顶' }, archive: { supported: false, reason: '当前 App 不支持归档' },
        fork: { supported: false }, handoff: { supported: false }, interactive_response: { supported: false },
      },
    });
    const view = renderChat('/chat/project-1/task-1');
    await view.findByText('现有消息');
    fireEvent.click(view.getByRole('button', { name: '任务一 操作' }));
    const rename = view.getByRole('menuitem', { name: '重命名' }) as HTMLButtonElement;
    const pin = view.getByRole('menuitem', { name: '置顶' }) as HTMLButtonElement;
    const archive = view.getByRole('menuitem', { name: '归档' }) as HTMLButtonElement;
    expect(rename.disabled).toBe(true);
    expect(rename.title).toBe('当前 App 不支持重命名');
    expect(pin.disabled).toBe(true);
    expect(archive.disabled).toBe(true);
  });
});
