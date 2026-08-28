import { fireEvent, render, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedbackProvider } from '@/components/ui';
import Layout from '@/components/Layout/Layout';
import { RefreshProvider } from '@/store/refresh';
import WorkspaceChat from './WorkspaceChat';

const mocks = vi.hoisted(() => ({
  listCodexProjects: vi.fn(),
  listCodexTasks: vi.fn(),
  readCodexTask: vi.fn(),
  waitCodexTask: vi.fn(),
  createCodexTask: vi.fn(),
  postCodexMessage: vi.fn(),
  patchCodexTask: vi.fn(),
  getCodexCapabilities: vi.fn(),
}));

vi.mock('@/api/codex', async () => {
  const actual = await vi.importActual<typeof import('@/api/codex')>('@/api/codex');
  return { ...actual, ...mocks };
});

const project = {
  device_id: 'device-1', device_name: 'Mac', project_id: 'project-1', project_name: '示例项目',
  host_id: 'local', kind: 'project', is_git_repository: true, available: true, online: true, order: 0,
};
const tasks = Array.from({ length: 6 }, (_, index) => ({
  id: `task-${index + 1}`, summary: `任务 ${index + 1}`, project_id: project.project_id,
  project_name: project.project_name, host_id: 'local', status: 'idle', modified_at: `2026-08-${20 - index}T00:00:00Z`,
}));

function renderWorkspace(path = '/tasks/device-1/project-1/task-1') {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <FeedbackProvider>
        <RefreshProvider>
          <Routes>
            <Route element={<Layout />}>
              <Route index element={<WorkspaceChat />} />
              <Route path="tasks/:deviceID/:projectID/:taskID" element={<WorkspaceChat />} />
            </Route>
          </Routes>
        </RefreshProvider>
      </FeedbackProvider>
    </MemoryRouter>,
  );
}

function snapshot(turns = [{
  id: 'turn-1', status: 'completed', items: [
    { id: 'user-1', type: 'user_message', content: [{ type: 'text', text: '现有消息' }] },
    {
      id: 'plan-1',
      type: 'plan',
      status: 'in_progress',
      text: '执行计划',
      raw_content: { steps: [{ title: '第一步', status: 'completed' }, { title: '第二步', status: 'in_progress' }] },
    },
    { id: 'agent-1', type: 'agent_message', text: '已完成' },
  ],
}]) {
  return { task: tasks[0], turns, page: { has_more: false, order: 'oldest_first' }, wait_cursor: 'wait-1' };
}

describe('Codex 专用工作区', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.listCodexProjects.mockResolvedValue({ projects: [project] });
    mocks.listCodexTasks.mockImplementation((_device: string, _project: string, cursor: string) =>
      Promise.resolve(cursor
        ? { sessions: [tasks[5]], has_more: false }
        : { sessions: tasks.slice(0, 5), cursor: 'offset:5', has_more: true }));
    mocks.readCodexTask.mockResolvedValue(snapshot());
    mocks.waitCodexTask.mockImplementation(() => new Promise(() => undefined));
    mocks.createCodexTask.mockResolvedValue({ ...tasks[0], id: 'created-task', status: 'active' });
    mocks.postCodexMessage.mockResolvedValue({ accepted: true });
    mocks.patchCodexTask.mockResolvedValue({ updated: true });
  });

  it('只渲染一层应用侧栏，项目默认精确展示 5 条并按 20 条读取更多', async () => {
    const view = renderWorkspace();
    await view.findByText('现有消息');
    expect(view.container.querySelectorAll('aside')).toHaveLength(1);
		for (let index = 1; index <= 5; index++) expect(view.getAllByText(`任务 ${index}`).length).toBeGreaterThan(0);
    expect(view.queryByText('任务 6')).toBeNull();

    fireEvent.click(view.getByRole('button', { name: '显示更多' }));
    expect(await view.findByText('任务 6')).toBeTruthy();
    expect(mocks.listCodexTasks).toHaveBeenLastCalledWith('device-1', 'project-1', 'offset:5', 20);

    fireEvent.click(view.getByRole('button', { name: '显示更少' }));
    expect(view.queryByText('任务 6')).toBeNull();
  });

  it('结构化计划默认折叠，并按 taskID 与 itemID 保存会话内展开状态', async () => {
    const view = renderWorkspace();
    const plan = await view.findByRole('button', { name: /执行计划/ });
    expect(plan.getAttribute('aria-expanded')).toBe('false');
    expect(view.queryByText('第一步')).toBeNull();
    expect(view.queryByText('第二步')).toBeNull();
    fireEvent.click(plan);
    expect(await view.findByText('第一步')).toBeTruthy();
    expect(await view.findByText('第二步')).toBeTruthy();
    expect(sessionStorage.getItem('cc-connect:plan:task-1:plan-1')).toBe('open');
  });

  it('1,000 个动态高度 Turn 只渲染虚拟窗口', async () => {
    const turns = Array.from({ length: 1000 }, (_, index) => ({
      id: `turn-${index}`,
      status: 'completed',
      items: [{ id: `agent-${index}`, type: 'agent_message', text: `内容 ${index} ${'x'.repeat(index % 100)}` }],
    }));
    mocks.readCodexTask.mockResolvedValue(snapshot(turns));
    const view = renderWorkspace();
    await waitFor(() => expect(view.container.querySelectorAll('[data-turn-id]').length).toBeGreaterThan(0));
    expect(view.container.querySelectorAll('[data-turn-id]').length).toBeLessThan(100);
  });

	it('新建任务的首条消息只调用创建接口', async () => {
		const view = renderWorkspace('/tasks/device-1/project-1/new');
		const input = await view.findByPlaceholderText('描述你要 Codex 完成的任务') as HTMLTextAreaElement;
		await waitFor(() => expect(input.disabled).toBe(false));
    fireEvent.change(input, { target: { value: '检查仓库' } });
    fireEvent.click(view.getByRole('button', { name: '发送' }));
    await waitFor(() => expect(mocks.createCodexTask).toHaveBeenCalledWith('device-1', 'project-1', '检查仓库'));
    expect(mocks.postCodexMessage).not.toHaveBeenCalled();
  });
});
