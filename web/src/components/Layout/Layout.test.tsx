import { fireEvent, render, screen } from '@testing-library/react';
import { MemoryRouter, Route, Routes, useLocation } from 'react-router-dom';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { FeedbackProvider } from '@/components/ui';
import { RefreshProvider } from '@/store/refresh';
import Layout from './Layout';
import SettingsLayout from '@/pages/Settings/SettingsLayout';

function CurrentPath() {
  return <output>{useLocation().pathname}</output>;
}

const mocks = vi.hoisted(() => ({
  listCodexProjects: vi.fn(),
  listCodexTasks: vi.fn(),
  patchCodexTask: vi.fn(),
  getCodexCapabilities: vi.fn(),
}));

vi.mock('@/api/codex', async () => {
  const actual = await vi.importActual<typeof import('@/api/codex')>('@/api/codex');
  return { ...actual, ...mocks };
});

describe('Codex Layout', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    mocks.listCodexProjects.mockResolvedValue({ projects: [] });
    mocks.listCodexTasks.mockResolvedValue({ sessions: [], has_more: false });
    mocks.getCodexCapabilities.mockResolvedValue({});
  });

  it('使用完整 flex 高度链，并在移动端复用同一侧栏抽屉', async () => {
    render(
      <MemoryRouter>
        <FeedbackProvider>
          <RefreshProvider>
            <Routes><Route element={<Layout />}><Route index element={<div>工作区</div>} /></Route></Routes>
          </RefreshProvider>
        </FeedbackProvider>
      </MemoryRouter>,
    );
    const navigation = await screen.findByRole('complementary', { name: '工作区导航' });
    expect(navigation.className).toContain('h-dvh');
    expect(navigation.className).toContain('-translate-x-full');
    expect(screen.getAllByRole('complementary')).toHaveLength(1);
    fireEvent.click(screen.getByRole('button', { name: '打开导航' }));
    expect(navigation.className).toContain('translate-x-0');
		fireEvent.click(screen.getAllByRole('button', { name: '关闭导航' })[0]);
    expect(navigation.className).toContain('-translate-x-full');
  });

  it('设置 Shell 完全替换工作区侧栏', () => {
    render(
      <MemoryRouter initialEntries={['/settings/general']}>
        <Routes><Route path="settings" element={<SettingsLayout />}><Route path="general" element={<div>常规内容</div>} /></Route></Routes>
      </MemoryRouter>,
    );
    expect(screen.getByRole('complementary', { name: '设置导航' })).toBeTruthy();
    expect(screen.queryByRole('complementary', { name: '工作区导航' })).toBeNull();
    expect(screen.getAllByRole('complementary')).toHaveLength(1);
    expect(screen.getByText('常规内容')).toBeTruthy();
  });

  it('设置返回只恢复工作区路由并拒绝旧设置循环', () => {
    sessionStorage.setItem('cc-connect:last-workspace', '/settings/feishu');
    render(
      <MemoryRouter initialEntries={['/settings/general']}>
        <Routes>
          <Route path="settings" element={<SettingsLayout />}><Route path="general" element={<div>常规内容</div>} /></Route>
          <Route path="*" element={<CurrentPath />} />
        </Routes>
      </MemoryRouter>,
    );
    fireEvent.click(screen.getByRole('button', { name: '返回应用' }));
    expect(screen.getByText('/')).toBeTruthy();
  });

  it('Runtime 不支持置顶和归档时禁用任务菜单且不发送写请求', async () => {
    mocks.listCodexProjects.mockResolvedValue({ projects: [{
      device_id: 'device-1', device_name: 'Mac', project_id: 'project-1', project_name: '示例项目',
      host_id: 'local', kind: 'project', is_git_repository: true, available: true, online: true, order: 0,
    }] });
    mocks.listCodexTasks.mockResolvedValue({
      sessions: [{ id: 'task-1', summary: '不可写任务', project_id: 'project-1', host_id: 'local' }],
      has_more: false,
    });
    mocks.getCodexCapabilities.mockResolvedValue({
      pin: { supported: false, reason: '当前 Codex App 不支持置顶' },
      archive: { supported: false, reason: '当前 Codex App 不支持归档' },
    });

    render(
      <MemoryRouter>
        <FeedbackProvider>
          <RefreshProvider>
            <Routes><Route element={<Layout />}><Route index element={<div>工作区</div>} /></Route></Routes>
          </RefreshProvider>
        </FeedbackProvider>
      </MemoryRouter>,
    );

    fireEvent.click(await screen.findByRole('button', { name: '不可写任务 操作' }));
    const actions = screen.getAllByRole('menuitem');
    expect(actions).toHaveLength(2);
    expect(actions.every((action) => action.hasAttribute('disabled'))).toBe(true);
    fireEvent.click(actions[1]);
    expect(mocks.patchCodexTask).not.toHaveBeenCalled();
  });
});
