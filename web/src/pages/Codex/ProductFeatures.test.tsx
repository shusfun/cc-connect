import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import i18n from '@/i18n';
import SearchPalette from '@/components/Layout/SearchPalette';
import NotificationPopover from '@/components/Layout/NotificationPopover';
import Scheduled from './Scheduled';
import Plugins from './Plugins';
import ArchivedTasks from '@/pages/Settings/ArchivedTasks';

const mocks = vi.hoisted(() => ({
  searchCodexTasks: vi.fn(), listCodexNotifications: vi.fn(), markCodexNotificationsRead: vi.fn(),
  listCodexAutomations: vi.fn(), createCodexAutomation: vi.fn(), updateCodexAutomation: vi.fn(), deleteCodexAutomation: vi.fn(),
  getCodexCapabilities: vi.fn(),
  listCodexTasks: vi.fn(), listCodexPlugins: vi.fn(), installCodexPlugin: vi.fn(), removeCodexPlugin: vi.fn(),
  listCodexProjects: vi.fn(), listArchivedCodexTasks: vi.fn(), restoreArchivedCodexTask: vi.fn(),
  notify: vi.fn(), confirm: vi.fn(),
}));

vi.mock('@/api/codex', async () => {
  const actual = await vi.importActual<typeof import('@/api/codex')>('@/api/codex');
  return { ...actual, ...mocks };
});

vi.mock('@/components/ui', () => ({ useFeedback: () => ({ notify: mocks.notify, confirm: mocks.confirm }) }));

const project = {
  device_id: 'device-1', device_name: 'Mac', project_id: 'project-1', project_name: '示例项目',
  host_id: 'local', kind: 'project', is_git_repository: true, available: true, online: true, order: 0,
};
const task = { id: 'task-1', summary: '检查项目', project_id: 'project-1', project_name: '示例项目', host_id: 'local' };
const workspace = {
  projects: [project], pages: {}, loading: false, error: '', keyFor: vi.fn(), loadMore: vi.fn(), showLess: vi.fn(), reload: vi.fn(), upsertTask: vi.fn(), removeTask: vi.fn(),
};

vi.mock('@/pages/Chat/CodexWorkspaceContext', () => ({ useCodexWorkspace: () => workspace }));

function Location() {
  return <output>{useLocation().pathname}</output>;
}

describe('Codex 产品能力页面', () => {
  beforeEach(async () => {
    vi.clearAllMocks();
    await i18n.changeLanguage('zh');
    mocks.confirm.mockResolvedValue(true);
    mocks.listCodexTasks.mockResolvedValue({ sessions: [task], has_more: false });
    mocks.getCodexCapabilities.mockResolvedValue({ automation_mutation: { supported: true } });
  });

  it('搜索使用 Runtime 结果、显示离线设备并支持键盘深链', async () => {
    mocks.searchCodexTasks.mockResolvedValue({
      results: [
        { device_id: 'device-1', task },
        { device_id: 'device-1', task: { ...task, id: 'task-2', summary: '第二个任务' } },
      ],
      offline_devices: [{ device_id: 'device-2', device_name: '旧 Mac', reason: 'Codex Runtime 离线' }],
    });
    render(<MemoryRouter><SearchPalette open onClose={vi.fn()} /><Location /></MemoryRouter>);
    const input = screen.getByRole('combobox', { name: '搜索项目和任务' });
    fireEvent.change(input, { target: { value: '项目' } });
    expect(await screen.findByText('旧 Mac · Codex Runtime 离线')).toBeTruthy();
    await waitFor(() => expect(screen.getByRole('option', { name: /检查项目/ }).getAttribute('aria-selected')).toBe('true'));
    fireEvent.keyDown(input, { key: 'ArrowDown' });
    await waitFor(() => expect(screen.getByRole('option', { name: /第二个任务/ }).getAttribute('aria-selected')).toBe('true'));
    fireEvent.keyDown(input, { key: 'Enter' });
    expect(screen.getByText('/tasks/device-1/project-1/task-2')).toBeTruthy();
    expect(mocks.searchCodexTasks).toHaveBeenCalledWith('项目', 40);
  });

  it('通知展示未读数并持久化全部已读游标', async () => {
    await i18n.changeLanguage('en');
    mocks.listCodexNotifications.mockResolvedValue({
      items: [{ id: 7, type: 'task_completed', outcome: 'success', occurred_at: '2026-08-28T00:00:00Z', read: false }],
      read_cursor: 0, unread: 1,
    });
    mocks.markCodexNotificationsRead.mockResolvedValue({ read_cursor: 7 });
    render(<MemoryRouter><NotificationPopover /></MemoryRouter>);
    expect(await screen.findByText('1')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Notifications' }));
    expect(await screen.findByText('Task completed')).toBeTruthy();
    fireEvent.click(await screen.findByRole('button', { name: 'Mark all read' }));
    await waitFor(() => expect(mocks.markCodexNotificationsRead).toHaveBeenCalledWith(7));
    expect(screen.queryByText('1')).toBeNull();
  });

  it('已安排支持真实 heartbeat 目标、创建、暂停和删除', async () => {
    const automation = { id: 'automation-1', name: '每日检查', kind: 'cron', prompt: '检查', rrule: 'FREQ=DAILY', status: 'ACTIVE' };
    mocks.listCodexAutomations.mockResolvedValue({ automations: [automation] });
    mocks.createCodexAutomation.mockResolvedValue({ ...automation, id: 'automation-2', name: '跟进任务', kind: 'heartbeat', target_thread_id: 'task-1' });
    mocks.updateCodexAutomation.mockResolvedValue({ ...automation, status: 'PAUSED' });
    mocks.deleteCodexAutomation.mockResolvedValue({ deleted: true });
    render(<MemoryRouter><Scheduled /></MemoryRouter>);
    expect(await screen.findByText('每日检查')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: '新建' }));
    fireEvent.change(screen.getByLabelText('名称'), { target: { value: '跟进任务' } });
    fireEvent.change(screen.getByLabelText('类型'), { target: { value: 'heartbeat' } });
    await waitFor(() => expect(screen.getByRole('option', { name: '检查项目 - 示例项目' })).toBeTruthy());
    fireEvent.change(screen.getByLabelText('目标任务'), { target: { value: 'task-1' } });
    fireEvent.change(screen.getByLabelText('计划规则'), { target: { value: 'FREQ=HOURLY' } });
    fireEvent.change(screen.getByLabelText('执行内容'), { target: { value: '继续处理' } });
    fireEvent.submit(screen.getByLabelText('名称').closest('form')!);
    await waitFor(() => expect(mocks.createCodexAutomation).toHaveBeenCalledWith('device-1', expect.objectContaining({
      kind: 'heartbeat', destination: 'thread', target_thread_id: 'task-1', project_id: '', execution_environment: '',
    })));
    fireEvent.click(screen.getByRole('button', { name: '暂停 每日检查' }));
    await waitFor(() => expect(mocks.updateCodexAutomation).toHaveBeenCalledWith('device-1', 'automation-1', { status: 'PAUSED' }));
    fireEvent.click(screen.getByRole('button', { name: '删除 每日检查' }));
    await waitFor(() => expect(mocks.deleteCodexAutomation).toHaveBeenCalledWith('device-1', 'automation-1'));
  });

  it('heartbeat 目标按服务端上限分页并显示加载错误', async () => {
    mocks.listCodexAutomations.mockResolvedValue({ automations: [] });
    mocks.listCodexTasks
      .mockResolvedValueOnce({ sessions: [task], has_more: true, cursor: 'next-page' })
      .mockRejectedValueOnce(new Error('Runtime offline'));
    render(<MemoryRouter><Scheduled /></MemoryRouter>);
    await waitFor(() => expect(mocks.listCodexTasks).toHaveBeenNthCalledWith(1, 'device-1', 'project-1', '', 50));
    await waitFor(() => expect(mocks.listCodexTasks).toHaveBeenNthCalledWith(2, 'device-1', 'project-1', 'next-page', 50));
    fireEvent.click(screen.getByRole('button', { name: '新建' }));
    fireEvent.change(screen.getByLabelText('类型'), { target: { value: 'heartbeat' } });
    expect((await screen.findByRole('alert')).textContent).toContain('Runtime offline');
  });

  it('自动化结果未知时保留错误，不伪造成功状态', async () => {
    mocks.listCodexAutomations.mockResolvedValue({ automations: [] });
    mocks.createCodexAutomation.mockRejectedValue(new Error('outcome is unknown and the write was not replayed'));
    render(<MemoryRouter><Scheduled /></MemoryRouter>);
    await screen.findByText('没有已安排任务');
    fireEvent.click(screen.getByRole('button', { name: '新建' }));
    fireEvent.change(screen.getByLabelText('名称'), { target: { value: '检查' } });
    fireEvent.change(screen.getByLabelText('计划规则'), { target: { value: 'FREQ=DAILY' } });
    fireEvent.change(screen.getByLabelText('执行内容'), { target: { value: '检查状态' } });
    fireEvent.submit(screen.getByLabelText('名称').closest('form')!);
    await waitFor(() => expect(mocks.notify).toHaveBeenCalledWith(expect.stringContaining('outcome is unknown'), 'error'));
  });

  it('Codex App 缺少自动化写能力时直接禁用新建', async () => {
    mocks.listCodexAutomations.mockResolvedValue({ automations: [] });
    mocks.getCodexCapabilities.mockResolvedValue({ automation_mutation: { supported: false } });
    render(<MemoryRouter><Scheduled /></MemoryRouter>);
    expect((await screen.findByRole('status')).textContent).toContain('当前 Codex App 版本不提供已安排任务编辑能力');
    expect(screen.getByRole('button', { name: '新建' }).hasAttribute('disabled')).toBe(true);
  });

  it('插件安装和移除都使用所选设备目录', async () => {
    mocks.listCodexPlugins.mockResolvedValue({ plugins: [
      { id: 'install@official', name: 'Install', marketplace: 'Official', installed: false, enabled: false },
      { id: 'remove@official', name: 'Remove', marketplace: 'Official', installed: true, enabled: true },
    ] });
    mocks.installCodexPlugin.mockResolvedValue({ id: 'install@official', installed: true });
    mocks.removeCodexPlugin.mockResolvedValue({ removed: true });
    render(<MemoryRouter><Plugins /></MemoryRouter>);
    fireEvent.click(await screen.findByRole('button', { name: '安装 Install' }));
    await waitFor(() => expect(mocks.installCodexPlugin).toHaveBeenCalledWith('device-1', 'install@official'));
    fireEvent.click(screen.getByRole('button', { name: '移除 Remove' }));
    await waitFor(() => expect(mocks.removeCodexPlugin).toHaveBeenCalledWith('device-1', 'remove@official'));
  });

  it('归档任务支持恢复和深链查看', async () => {
    mocks.listCodexProjects.mockResolvedValue({ projects: [project] });
    mocks.listArchivedCodexTasks.mockResolvedValue({ sessions: [task, { ...task, id: 'task-2', summary: '待恢复' }], has_more: false });
    mocks.restoreArchivedCodexTask.mockResolvedValue({ restored: true });
    render(<MemoryRouter><Routes><Route path="*" element={<><ArchivedTasks /><Location /></>} /></Routes></MemoryRouter>);
    await waitFor(() => expect(mocks.listArchivedCodexTasks).toHaveBeenCalledWith('device-1', 50));
    fireEvent.click(await screen.findByRole('button', { name: '查看 检查项目' }));
    expect(screen.getByText('/tasks/device-1/project-1/task-1')).toBeTruthy();
    fireEvent.click(screen.getAllByRole('button', { name: '恢复' })[1]);
    await waitFor(() => expect(mocks.restoreArchivedCodexTask).toHaveBeenCalledWith('device-1', 'task-2', 'local'));
  });
});
